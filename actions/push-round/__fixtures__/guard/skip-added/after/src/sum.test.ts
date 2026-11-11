import { describe, expect, it } from 'vitest'
import { sum } from './sum'

describe('sum', () => {
  it('adds two numbers', () => {
    expect(sum(1, 2)).toEqual(3)
  })

  it.skip('adds a negative number', () => {
    expect(sum(1, -2)).toEqual(-1)
  })
})
